--liquibase formatted sql

--changeset Nicolas Griesdorn bfa9aa6d stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-05-21
				:
	Description	: SP used in CRM to allow users to fulfill currently pending Amplex or Cooper General Marketplace orders or allow the user to fill device details on those orders as well -- noqa: LT05
				:
	NG20230731	: Moved already found ESN/SIM logic to just Missing Details option instead of the entire report as it was throwing errors when filling an order when it should not have been -- noqa: LT05
	NG20230914  : Opened new option for Nic G. and Matt M. in order to submit missing SIMs to existing ESNs. Added remaining BYOP Logic to report
	NG20230918  : Added Join to #ESNList1 to cut down on caching the whole orders table, formatting changed as suggested
	NG20230929  : Changed Description above to match report, changed where from P1.etc to P.etc as it was updating to many records
	NG20231030  : Added Error Handling for Ops to check if the ESN is in the Tracfone.tblHandsetESN table
	NG20231031  : Added Amplex and Cooper specific error handling to support new Error Handling for Ops, added UserOverride option for Matt M.(IT), Nic G.(IT), Travis R.(Supply Chain) -- noqa: LT05
	NG20231129  : Added Tyler Fee to users that can fill orders
============================================= */
ALTER PROCEDURE [Report].[P_Report_Fulfill_Pending_Marketplace_Orders]
    (
        @SessionID INT
        , @UserID INT
        , @UserOverride BIT
        , @Option INT
        , @OrderNo INT
        , @ESN NVARCHAR(MAX)
        , @SIM NVARCHAR(MAX)
        , @ProductID INT
    )
AS
BEGIN TRY
    IF ISNULL(@SessionID, 0) <> 2
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF EXISTS (SELECT Dropship_Account_ID FROM dbo.Orders WHERE Order_No = @OrderNo AND Dropship_Account_ID NOT IN (94074, 154374))
        RAISERROR (
            'This report does not support functionality for Alphacomm, HubX, and Marketplace vendors. Please contact IT Support for assistance.',
            12,
            1
        );

    IF NOT EXISTS (SELECT Order_No FROM dbo.Order_No WHERE Order_No = @OrderNo)
        RAISERROR ('The provided Order cannot be located. Please supply the correct OrderNo and try again.', 12, 1);

    DROP TABLE IF EXISTS #ESNList;
    DROP TABLE IF EXISTS #ESNList1;

    CREATE TABLE #ESNList
    (
        ESN_SIM VARCHAR(100)
        , Order_No INT
        , Product_ID INT
        , SIM VARCHAR(100)
        , KitNumber NVARCHAR(50)
    );

    INSERT INTO #ESNList
    (ESN_SIM, Order_No, Product_ID, SIM)
    VALUES
    (@ESN, @OrderNo, @ProductID, @SIM)

    SELECT TOP 1 o.Order_No, o.ID
    INTO #ESNList1
    FROM dbo.Orders AS o
    JOIN #ESNList AS E ON E.Order_No = o.Order_No
    --NG20230918
    WHERE
        (o.Order_No = @OrderNo AND o.Product_ID = @ProductID AND o.SKU IS NULL)
        OR (o.Order_No = @OrderNo AND o.Product_ID = @ProductID AND o.SKU = @ESN)

    IF @Option = 0
        BEGIN

            SELECT
                o.Order_No
                , o.SKU
                , oia.AddonsValue AS [ICCID]
                , O.Product_ID
                , CASE WHEN oia1.AddonsValue IS NOT NULL THEN 'Yes' ELSE 'No' END AS [IsKitted]
                , pak.Activation_Type
                , oia1.AddonsValue AS [Kit Number]
                , o.Name
                , pm.VendorSku AS [Part Number]
                , ONum.Process
                , ONum.Filled
                , ONum.Void
                , ONum.Paid
                , CASE WHEN a.Account_Name = 'Branded Handset' THEN 'Amplex' ELSE a.Account_Name END AS [Vendor Name]
            FROM dbo.Orders AS o
            JOIN dbo.Order_No AS ONum
                ON ONum.Order_No = O.Order_No
            JOIN dbo.Account AS a
                ON a.Account_ID = o.Dropship_Account_ID
            JOIN Products.tblProductMapping AS pm
                ON o.Product_ID = pm.ProductID
            LEFT JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('SimType', 'SimBYOPType')
                ON oia.OrderID = o.ID
            LEFT JOIN
                dbo.tblOrderItemAddons AS oia1
                    JOIN dbo.tblAddonFamily AS af2
                        ON
                            af2.AddonID = oia1.AddonsID
                            AND af2.AddonTypeName IN ('KitNoType')
                ON oia1.OrderID = o.ID
            LEFT JOIN dbo.Phone_Active_Kit AS pak
                ON
                    pak.PONumber = o.Order_No
                    AND pak.Sim_ID = @ESN
            WHERE o.Order_No = @OrderNo

        END;
    --Set the kit number
    UPDATE #ESNList SET KitNumber = NEWID();
    --------------------------------------------------------------------------------------------------
    --------------------------------------------------------------------------------------------------
    --Add data to Phone_Active_Kit
    IF @Option = 1
        BEGIN

            IF ISNULL(@ProductID, 0) = 0
                RAISERROR ('There was no provided ProductId for this Order. Please enter the correct ProductId and try again.', 14, 1);

            IF NOT EXISTS (SELECT Product_ID FROM dbo.Orders WHERE Product_ID = @ProductID)
                RAISERROR ('The provided ProductId does not exist for this Order. Please enter the correct ProductId and try again.', 14, 1);

            --NG20230731
            IF
                EXISTS (
                    SELECT P.Sim_ID
                    FROM dbo.Phone_Active_Kit AS P
                    JOIN dbo.Order_No AS ONum ON ONum.Order_No = P.PONumber
                    WHERE
                        P.Sim_ID = @ESN AND P.Status = 1 AND P.Assigned_Merchant_ID != ONum.Account_ID
                        OR P.Sim_ID = @SIM AND P.Status = 1 AND P.Assigned_Merchant_ID != ONum.Account_ID
                )
                RAISERROR (
                    'This ESN or SIM has already been entered or has an old order still attached that needs an RMA order generated, please RMA the old order or contact IT Support.', -- noqa: LT05
                    12,
                    1
                );

            IF ISNULL(@ESN, '') = '' AND @SIM IS NOT NULL OR ISNULL(@SIM, '') = '' AND @ESN IS NOT NULL
                RAISERROR ('Amplex requires both ESN and SIM values. Please provide both and try again.', 14, 1);

            --NG20230914
            IF
                EXISTS (
                    SELECT P.Sim_ID
                    FROM dbo.Phone_Active_Kit AS P
                    JOIN dbo.Order_No AS ONum ON ONum.Order_No = P.PONumber
                    WHERE P.Status = 1 AND P.Sim_ID = @ESN AND P.Kit_Number IS NULL AND @UserID NOT IN (279685, 259617)
                )
                RAISERROR ('There is an ESN or SIM in the PAK table already, please reach out to the IT Support team to investigate.', 14, 1);

            --NG20230914
            IF
                EXISTS (
                    SELECT P.*
                    FROM dbo.Phone_Active_Kit AS P
                    WHERE P.Sim_ID = @ESN AND P.Activation_Type != 'byop' AND P.Status != 0 AND P.Kit_Number IS NOT NULL
                )
                RAISERROR (
                    'This ESN or SIM has either already been entered or there are no longer any available items on the order, please check the order and try again.', -- noqa: LT05
                    14,
                    1
                );

            --NG20230914
            IF
                EXISTS (
                    SELECT P.Sim_ID
                    FROM dbo.Phone_Active_Kit AS P
                    JOIN dbo.Order_No AS ONum ON ONum.Order_No = P.PONumber
                    WHERE P.Status = 1 AND P.Sim_ID = @ESN AND P.Kit_Number IS NULL AND @UserID IN (279685, 259617)
                )
                BEGIN

                    UPDATE PAK
                    SET
                        Kit_Number = E.KitNumber
                        , Date_Updated = GETDATE()
                        , User_Updated = CURRENT_USER
                    FROM dbo.Phone_Active_Kit AS PAK
                    JOIN #ESNList AS E ON PAK.Sim_ID = E.ESN_SIM
                    WHERE PAK.Sim_ID = @ESN AND Status = 1

                    INSERT INTO dbo.Phone_Active_Kit
                    (
                        Sim_ID
                        , Product_ID
                        , order_no
                        , Assigned_Merchant_ID
                        , PONumber
                        , Kit_Number
                        , Carrier_ID
                        , Kit_Number_Remove
                        , IMEI_ESN
                        , Plan_ID
                        , Pin_Number
                        , Area_Code
                        , Zip_Code
                        , City
                        , Expiration_Date
                        , Active_Status
                        , Date_Created
                        , User_Created
                        , Date_Updated
                        , User_Updated
                        , [Status]
                        , Active_States
                        , VendorSku
                        , Activation_Type
                        , AFCode
                        , Owner_ID
                        , Spiff_Discount_Type
                        , Spiff_Amount
                        , VendorAccountID
                        , IsSimExpress
                        , IsReassignable
                        , CommissionVendorAccountId
                        , MaSpiffAmount
                        , status2
                    )
                    -- Add SIM
                    SELECT
                        E.SIM AS Sim_ID
                        , E.Product_ID AS Product_ID
                        , 0 AS order_no
                        , ONum.Account_ID AS Assigned_Merchant_ID
                        , E.Order_No AS PONumber
                        , E.KitNumber AS Kit_Number
                        , pcm.CarrierId AS Carrier_ID
                        , NULL AS Kit_Number_Remove
                        , '' AS IMEI_ESN
                        , '' AS Plan_ID
                        , '' AS Pin_Number
                        , '' AS Area_Code
                        , '' AS Zip_Code
                        , '' AS City
                        , '2099-01-01' AS Expiration_Date
                        , 0 AS Active_Status
                        , GETDATE() AS Date_Created
                        , 'FulfillCRMReport' AS User_Created
                        , GETDATE() AS Date_Updated
                        , 'FulfillCRMReport' AS User_Updated
                        , 1 AS [Status]
                        , '' AS Active_States
                        , '' AS VendorSku
                        , 'branded' AS Activation_Type -- lower case b
                        , '' AS AFCode
                        , 0 AS Owner_ID
                        , '' AS Spiff_Discount_Type
                        , 0 AS Spiff_Amount
                        , 58361 AS VendorAccountID
                        , 0 AS IsSimExpress
                        , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                        , 58361 AS CommissionVendorAccountId
                        , 0 AS MaSpiffAmount
                        , 10 AS status2
                    FROM #ESNList AS E
                    LEFT JOIN Account.tblIsReassignableProductIDs AS r
                        ON r.Product_ID = E.Product_ID
                    LEFT JOIN Products.tblProductCarrierMapping AS pcm
                        ON E.Product_ID = pcm.ProductId
                    LEFT JOIN dbo.Order_No AS ONum
                        ON ONum.Order_No = E.Order_No
                    WHERE E.SIM IS NOT NULL
                END;

            IF @UserOverride = 0 --NG20231031
                BEGIN
                    --Amplex Order Check NG20231031
                    IF EXISTS (SELECT o.* FROM dbo.Orders AS o WHERE o.Order_No = @OrderNo AND o.Dropship_Account_ID = 94074)
                        BEGIN

                            --NG20230914
                            IF
                                NOT EXISTS (
                                    SELECT P.Sim_ID
                                    FROM dbo.Phone_Active_Kit AS P
                                    JOIN dbo.Order_No AS ONum ON ONum.Order_No = P.PONumber
                                    JOIN dbo.Orders AS o ON o.Order_No = ONum.Order_No
                                    WHERE
                                        P.Status = 1
                                        AND P.PONumber = @OrderNo
                                        AND P.Assigned_Merchant_ID = ONum.Account_ID
                                        AND P.Sim_ID = @ESN
                                        AND P.Kit_Number IS NOT NULL
                                )
                                BEGIN

                                    --NG20230914
                                    IF
                                        EXISTS (
                                            SELECT P.*
                                            FROM dbo.Phone_Active_Kit AS P
                                            WHERE P.Sim_ID = @ESN AND P.Activation_Type != 'byop' AND P.Status != 0
                                        )
                                        RAISERROR (
                                            'This ESN or SIM has either already been entered or there are no longer any available items on the order, please check the order and try again.', -- noqa: LT05
                                            14,
                                            1
                                        );

                                    --NG20231030
                                    IF
                                        NOT EXISTS (
                                            SELECT t.*
                                            FROM Tracfone.tblHandsetESN AS t
                                            JOIN dbo.Orders AS o ON o.Order_No = t.OrderNo
                                            WHERE o.Order_No = @OrderNo AND t.SimOrPhone = @ESN
                                        )
                                        BEGIN
                                            RAISERROR (
                                                'This ESN or SIM is not currently in the Tracfone Handset ESN table, Please contact T-CETRA Supply Chain to help with this order.', -- noqa: LT05
                                                14,
                                                1
                                            );
                                        END

                                    INSERT INTO dbo.Phone_Active_Kit
                                    (
                                        Sim_ID
                                        , Product_ID
                                        , order_no
                                        , Assigned_Merchant_ID
                                        , PONumber
                                        , Kit_Number
                                        , Carrier_ID
                                        , Kit_Number_Remove
                                        , IMEI_ESN
                                        , Plan_ID
                                        , Pin_Number
                                        , Area_Code
                                        , Zip_Code
                                        , City
                                        , Expiration_Date
                                        , Active_Status
                                        , Date_Created
                                        , User_Created
                                        , Date_Updated
                                        , User_Updated
                                        , [Status]
                                        , Active_States
                                        , VendorSku
                                        , Activation_Type
                                        , AFCode
                                        , Owner_ID
                                        , Spiff_Discount_Type
                                        , Spiff_Amount
                                        , VendorAccountID
                                        , IsSimExpress
                                        , IsReassignable
                                        , CommissionVendorAccountId
                                        , MaSpiffAmount
                                        , status2
                                    )
                                    -- Add ESN
                                    SELECT
                                        E.ESN_SIM AS Sim_ID
                                        , E.Product_ID AS Product_ID
                                        , 0 AS order_no
                                        , ONum.Account_ID AS Assigned_Merchant_ID
                                        , E.Order_No AS PONumber
                                        , E.KitNumber AS Kit_Number
                                        , pcm.CarrierId AS Carrier_ID
                                        , NULL AS Kit_Number_Remove
                                        , '' AS IMEI_ESN
                                        , '' AS Plan_ID
                                        , '' AS Pin_Number
                                        , '' AS Area_Code
                                        , '' AS Zip_Code
                                        , '' AS City
                                        , '2099-01-01' AS Expiration_Date
                                        , 0 AS Active_Status
                                        , GETDATE() AS Date_Created
                                        , 'FulfillCRMReport' AS User_Created
                                        , GETDATE() AS Date_Updated
                                        , 'FulfillCRMReport' AS User_Updated
                                        , 1 AS [Status]
                                        , '' AS Active_States
                                        , '' AS VendorSku
                                        , 'branded' AS Activation_Type -- lower case b
                                        , '' AS AFCode
                                        , 0 AS Owner_ID
                                        , '' AS Spiff_Discount_Type
                                        , 0 AS Spiff_Amount
                                        , 58361 AS VendorAccountID
                                        , 0 AS IsSimExpress
                                        , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                                        , 58361 AS CommissionVendorAccountId
                                        , 0 AS MaSpiffAmount
                                        , 10 AS status2
                                    FROM #ESNList AS E
                                    LEFT JOIN Account.tblIsReassignableProductIDs AS r
                                        ON r.Product_ID = E.Product_ID
                                    LEFT JOIN Products.tblProductCarrierMapping AS pcm
                                        ON E.Product_ID = pcm.ProductId
                                    LEFT JOIN dbo.Order_No AS ONum
                                        ON ONum.Order_No = E.Order_No
                                    UNION
                                    -- Add SIM
                                    SELECT
                                        E.SIM AS Sim_ID
                                        , E.Product_ID AS Product_ID
                                        , 0 AS order_no
                                        , ONum.Account_ID AS Assigned_Merchant_ID
                                        , E.Order_No AS PONumber
                                        , E.KitNumber AS Kit_Number
                                        , pcm.CarrierId AS Carrier_ID
                                        , NULL AS Kit_Number_Remove
                                        , '' AS IMEI_ESN
                                        , '' AS Plan_ID
                                        , '' AS Pin_Number
                                        , '' AS Area_Code
                                        , '' AS Zip_Code
                                        , '' AS City
                                        , '2099-01-01' AS Expiration_Date
                                        , 0 AS Active_Status
                                        , GETDATE() AS Date_Created
                                        , 'FulfillCRMReport' AS User_Created
                                        , GETDATE() AS Date_Updated
                                        , 'FulfillCRMReport' AS User_Updated
                                        , 1 AS [Status]
                                        , '' AS Active_States
                                        , '' AS VendorSku
                                        , 'branded' AS Activation_Type -- lower case b
                                        , '' AS AFCode
                                        , 0 AS Owner_ID
                                        , '' AS Spiff_Discount_Type
                                        , 0 AS Spiff_Amount
                                        , 58361 AS VendorAccountID
                                        , 0 AS IsSimExpress
                                        , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                                        , 58361 AS CommissionVendorAccountId
                                        , 0 AS MaSpiffAmount
                                        , 10 AS status2
                                    FROM #ESNList AS E
                                    LEFT JOIN Account.tblIsReassignableProductIDs AS r
                                        ON r.Product_ID = E.Product_ID
                                    LEFT JOIN Products.tblProductCarrierMapping AS pcm
                                        ON E.Product_ID = pcm.ProductId
                                    LEFT JOIN dbo.Order_No AS ONum
                                        ON ONum.Order_No = E.Order_No
                                    WHERE E.SIM IS NOT NULL;
                                END
                        END
                END;

            IF @UserOverride = 1 --NG20231031
                BEGIN

                    IF @UserID NOT IN (279685, 259617, 145761, 257210)
                        RAISERROR (
                            'This user is not authorized to override this order, please contact T-CETRA Supply Chain team if you need to override this order.', -- noqa: LT05
                            14,
                            1
                        );

                    --Amplex Order Check NG20231031
                    IF EXISTS (SELECT o.* FROM dbo.Orders AS o WHERE o.Order_No = @OrderNo AND o.Dropship_Account_ID = 94074)
                        BEGIN

                            --NG20230914
                            IF
                                NOT EXISTS (
                                    SELECT P.Sim_ID
                                    FROM dbo.Phone_Active_Kit AS P
                                    JOIN dbo.Order_No AS ONum ON ONum.Order_No = P.PONumber
                                    JOIN dbo.Orders AS o ON o.Order_No = ONum.Order_No
                                    WHERE
                                        P.Status = 1
                                        AND P.PONumber = @OrderNo
                                        AND P.Assigned_Merchant_ID = ONum.Account_ID
                                        AND P.Sim_ID = @ESN
                                        AND P.Kit_Number IS NOT NULL
                                )
                                BEGIN

                                    --NG20230914
                                    IF
                                        EXISTS (
                                            SELECT P.*
                                            FROM dbo.Phone_Active_Kit AS P
                                            WHERE P.Sim_ID = @ESN AND P.Activation_Type != 'byop' AND P.Status != 0
                                        )
                                        RAISERROR (
                                            'This ESN or SIM has either already been entered or there are no longer any available items on the order, please check the order and try again.', -- noqa: LT05
                                            14,
                                            1
                                        );
                                END

                            INSERT INTO dbo.Phone_Active_Kit
                            (
                                Sim_ID
                                , Product_ID
                                , order_no
                                , Assigned_Merchant_ID
                                , PONumber
                                , Kit_Number
                                , Carrier_ID
                                , Kit_Number_Remove
                                , IMEI_ESN
                                , Plan_ID
                                , Pin_Number
                                , Area_Code
                                , Zip_Code
                                , City
                                , Expiration_Date
                                , Active_Status
                                , Date_Created
                                , User_Created
                                , Date_Updated
                                , User_Updated
                                , [Status]
                                , Active_States
                                , VendorSku
                                , Activation_Type
                                , AFCode
                                , Owner_ID
                                , Spiff_Discount_Type
                                , Spiff_Amount
                                , VendorAccountID
                                , IsSimExpress
                                , IsReassignable
                                , CommissionVendorAccountId
                                , MaSpiffAmount
                                , status2
                            )
                            -- Add ESN
                            SELECT
                                E.ESN_SIM AS Sim_ID
                                , E.Product_ID AS Product_ID
                                , 0 AS order_no
                                , ONum.Account_ID AS Assigned_Merchant_ID
                                , E.Order_No AS PONumber
                                , E.KitNumber AS Kit_Number
                                , pcm.CarrierId AS Carrier_ID
                                , NULL AS Kit_Number_Remove
                                , '' AS IMEI_ESN
                                , '' AS Plan_ID
                                , '' AS Pin_Number
                                , '' AS Area_Code
                                , '' AS Zip_Code
                                , '' AS City
                                , '2099-01-01' AS Expiration_Date
                                , 0 AS Active_Status
                                , GETDATE() AS Date_Created
                                , 'FulfillCRMReport' AS User_Created
                                , GETDATE() AS Date_Updated
                                , 'FulfillCRMReport' AS User_Updated
                                , 1 AS [Status]
                                , '' AS Active_States
                                , '' AS VendorSku
                                , 'branded' AS Activation_Type -- lower case b
                                , '' AS AFCode
                                , 0 AS Owner_ID
                                , '' AS Spiff_Discount_Type
                                , 0 AS Spiff_Amount
                                , 58361 AS VendorAccountID
                                , 0 AS IsSimExpress
                                , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                                , 58361 AS CommissionVendorAccountId
                                , 0 AS MaSpiffAmount
                                , 10 AS status2
                            FROM #ESNList AS E
                            LEFT JOIN Account.tblIsReassignableProductIDs AS r
                                ON r.Product_ID = E.Product_ID
                            LEFT JOIN Products.tblProductCarrierMapping AS pcm
                                ON E.Product_ID = pcm.ProductId
                            LEFT JOIN dbo.Order_No AS ONum
                                ON ONum.Order_No = E.Order_No
                            UNION
                            -- Add SIM
                            SELECT
                                E.SIM AS Sim_ID
                                , E.Product_ID AS Product_ID
                                , 0 AS order_no
                                , ONum.Account_ID AS Assigned_Merchant_ID
                                , E.Order_No AS PONumber
                                , E.KitNumber AS Kit_Number
                                , pcm.CarrierId AS Carrier_ID
                                , NULL AS Kit_Number_Remove
                                , '' AS IMEI_ESN
                                , '' AS Plan_ID
                                , '' AS Pin_Number
                                , '' AS Area_Code
                                , '' AS Zip_Code
                                , '' AS City
                                , '2099-01-01' AS Expiration_Date
                                , 0 AS Active_Status
                                , GETDATE() AS Date_Created
                                , 'FulfillCRMReport' AS User_Created
                                , GETDATE() AS Date_Updated
                                , 'FulfillCRMReport' AS User_Updated
                                , 1 AS [Status]
                                , '' AS Active_States
                                , '' AS VendorSku
                                , 'branded' AS Activation_Type -- lower case b
                                , '' AS AFCode
                                , 0 AS Owner_ID
                                , '' AS Spiff_Discount_Type
                                , 0 AS Spiff_Amount
                                , 58361 AS VendorAccountID
                                , 0 AS IsSimExpress
                                , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                                , 58361 AS CommissionVendorAccountId
                                , 0 AS MaSpiffAmount
                                , 10 AS status2
                            FROM #ESNList AS E
                            LEFT JOIN Account.tblIsReassignableProductIDs AS r
                                ON r.Product_ID = E.Product_ID
                            LEFT JOIN Products.tblProductCarrierMapping AS pcm
                                ON E.Product_ID = pcm.ProductId
                            LEFT JOIN dbo.Order_No AS ONum
                                ON ONum.Order_No = E.Order_No
                            WHERE E.SIM IS NOT NULL;
                        END
                END;

            --Cooper General Exception NG20231031
            IF EXISTS (SELECT o.* FROM dbo.Orders AS o WHERE o.Order_No = @OrderNo AND o.Dropship_Account_ID = 154374)
                BEGIN

                    --NG20230914
                    IF
                        NOT EXISTS (
                            SELECT P.Sim_ID
                            FROM dbo.Phone_Active_Kit AS P
                            JOIN dbo.Order_No AS ONum ON ONum.Order_No = P.PONumber
                            JOIN dbo.Orders AS o ON o.Order_No = ONum.Order_No
                            WHERE
                                P.Status = 1
                                AND P.PONumber = @OrderNo
                                AND P.Assigned_Merchant_ID = ONum.Account_ID
                                AND P.Sim_ID = @ESN
                                AND P.Kit_Number IS NOT NULL
                        )
                        BEGIN

                            --NG20230914
                            IF
                                EXISTS (
                                    SELECT P.* FROM dbo.Phone_Active_Kit AS P WHERE P.Sim_ID = @ESN AND P.Activation_Type != 'byop' AND P.Status != 0
                                )
                                RAISERROR (
                                    'This ESN or SIM has either already been entered or there are no longer any available items on the order, please check the order and try again.', -- noqa: LT05
                                    14,
                                    1
                                );

                            INSERT INTO dbo.Phone_Active_Kit
                            (
                                Sim_ID
                                , Product_ID
                                , order_no
                                , Assigned_Merchant_ID
                                , PONumber
                                , Kit_Number
                                , Carrier_ID
                                , Kit_Number_Remove
                                , IMEI_ESN
                                , Plan_ID
                                , Pin_Number
                                , Area_Code
                                , Zip_Code
                                , City
                                , Expiration_Date
                                , Active_Status
                                , Date_Created
                                , User_Created
                                , Date_Updated
                                , User_Updated
                                , [Status]
                                , Active_States
                                , VendorSku
                                , Activation_Type
                                , AFCode
                                , Owner_ID
                                , Spiff_Discount_Type
                                , Spiff_Amount
                                , VendorAccountID
                                , IsSimExpress
                                , IsReassignable
                                , CommissionVendorAccountId
                                , MaSpiffAmount
                                , status2
                            )
                            -- Add ESN
                            SELECT
                                E.ESN_SIM AS Sim_ID
                                , E.Product_ID AS Product_ID
                                , 0 AS order_no
                                , ONum.Account_ID AS Assigned_Merchant_ID
                                , E.Order_No AS PONumber
                                , E.KitNumber AS Kit_Number
                                , pcm.CarrierId AS Carrier_ID
                                , NULL AS Kit_Number_Remove
                                , '' AS IMEI_ESN
                                , '' AS Plan_ID
                                , '' AS Pin_Number
                                , '' AS Area_Code
                                , '' AS Zip_Code
                                , '' AS City
                                , '2099-01-01' AS Expiration_Date
                                , 0 AS Active_Status
                                , GETDATE() AS Date_Created
                                , 'FulfillCRMReport' AS User_Created
                                , GETDATE() AS Date_Updated
                                , 'FulfillCRMReport' AS User_Updated
                                , 1 AS [Status]
                                , '' AS Active_States
                                , '' AS VendorSku
                                , 'branded' AS Activation_Type -- lower case b
                                , '' AS AFCode
                                , 0 AS Owner_ID
                                , '' AS Spiff_Discount_Type
                                , 0 AS Spiff_Amount
                                , 58361 AS VendorAccountID
                                , 0 AS IsSimExpress
                                , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                                , 58361 AS CommissionVendorAccountId
                                , 0 AS MaSpiffAmount
                                , 10 AS status2
                            FROM #ESNList AS E
                            LEFT JOIN Account.tblIsReassignableProductIDs AS r
                                ON r.Product_ID = E.Product_ID
                            LEFT JOIN Products.tblProductCarrierMapping AS pcm
                                ON E.Product_ID = pcm.ProductId
                            LEFT JOIN dbo.Order_No AS ONum
                                ON ONum.Order_No = E.Order_No
                            UNION
                            -- Add SIM
                            SELECT
                                E.SIM AS Sim_ID
                                , E.Product_ID AS Product_ID
                                , 0 AS order_no
                                , ONum.Account_ID AS Assigned_Merchant_ID
                                , E.Order_No AS PONumber
                                , E.KitNumber AS Kit_Number
                                , pcm.CarrierId AS Carrier_ID
                                , NULL AS Kit_Number_Remove
                                , '' AS IMEI_ESN
                                , '' AS Plan_ID
                                , '' AS Pin_Number
                                , '' AS Area_Code
                                , '' AS Zip_Code
                                , '' AS City
                                , '2099-01-01' AS Expiration_Date
                                , 0 AS Active_Status
                                , GETDATE() AS Date_Created
                                , 'FulfillCRMReport' AS User_Created
                                , GETDATE() AS Date_Updated
                                , 'FulfillCRMReport' AS User_Updated
                                , 1 AS [Status]
                                , '' AS Active_States
                                , '' AS VendorSku
                                , 'branded' AS Activation_Type -- lower case b
                                , '' AS AFCode
                                , 0 AS Owner_ID
                                , '' AS Spiff_Discount_Type
                                , 0 AS Spiff_Amount
                                , 58361 AS VendorAccountID
                                , 0 AS IsSimExpress
                                , IIF(ISNULL(r.IsReassignable, 0) <> 0, 1, 0) AS IsReassignable
                                , 58361 AS CommissionVendorAccountId
                                , 0 AS MaSpiffAmount
                                , 10 AS status2
                            FROM #ESNList AS E
                            LEFT JOIN Account.tblIsReassignableProductIDs AS r
                                ON r.Product_ID = E.Product_ID
                            LEFT JOIN Products.tblProductCarrierMapping AS pcm
                                ON E.Product_ID = pcm.ProductId
                            LEFT JOIN dbo.Order_No AS ONum
                                ON ONum.Order_No = E.Order_No
                            WHERE E.SIM IS NOT NULL;
                        END
                END;


            ------------------------------------------------------------------------------------------------------------------------------------
            --Update Order Info
            UPDATE OrdS
            SET
                SKU = E.ESN_SIM
                , OrdS.OptQuant = rt.Period
            --SELECT *
            FROM dbo.Orders AS OrdS
            JOIN #ESNList1 AS E1
                ON E1.ID = OrdS.ID
            JOIN #ESNList AS E
                ON E.Order_No = E1.Order_No
            JOIN Products.tblReturnTerms AS rt
                ON e.Product_ID = rt.ProductId
            WHERE OrdS.SKU IS NULL
            --------------------------------------------------------------------------------------------------------------------------------------
            --Create records in tblSerializedInventorySold
            INSERT INTO MarketPlace.tblSerializedInventorySold
            (ProductID, SerialNumber, CreateDate, CreateUser, [Status])
            -- Add ESN
            SELECT
                E.Product_ID AS ProductID
                , E.ESN_SIM AS SerialNumber
                , GETDATE() AS CreateDate
                , CURRENT_USER AS CreateUser
                , 1 AS [Status]
            FROM #ESNList AS E
            WHERE E.ESN_SIM NOT IN (SELECT sis.SerialNumber FROM MarketPlace.tblSerializedInventorySold AS sis WHERE sis.SerialNumber = E.ESN_SIM)
            UNION
            -- Add SIM
            SELECT
                E.Product_ID AS ProductID
                , E.SIM AS SerialNumber
                , GETDATE() AS CreateDate
                , CURRENT_USER AS CreateUser
                , 1 AS [Status]
            FROM #ESNList AS E
            WHERE E.SIM NOT IN (SELECT sis.SerialNumber FROM MarketPlace.tblSerializedInventorySold AS sis WHERE sis.SerialNumber = E.SIM);

            --------------------------------------------------------------------------------------------------------------------------------------
            ---- BYOP Logic --NG20230914

            DROP TABLE IF EXISTS #OldESN
            DROP TABLE IF EXISTS #OldSIM

            SELECT p.*
            INTO #OldESN
            FROM dbo.Phone_Active_Kit AS P
            JOIN #ESNList AS E
                ON E.ESN_SIM = P.Sim_ID
            WHERE P.Status = 1 AND P.Activation_Type = 'byop'

            SELECT p.*
            INTO #OldSIM
            FROM dbo.Phone_Active_Kit AS P
            JOIN #ESNList AS E
                ON E.SIM = P.Sim_ID
            WHERE P.Status = 1 AND P.Activation_Type = 'byop'

            UPDATE p
            SET
                status = 0
                , p.Date_Updated = GETDATE()
                , p.User_Updated = 'FulfillCRMReport'
            --SELECT *
            FROM
                dbo.Phone_Active_Kit AS p
            JOIN #OldESN AS oe
                ON oe.ID = P.ID

            UPDATE p
            SET
                status = 0
                , p.Date_Updated = GETDATE()
                , p.User_Updated = 'FulfillCRMReport'
            --SELECT *
            FROM
                dbo.Phone_Active_Kit AS p
            JOIN
                #OldSIM AS oe
                ON oe.ID = P.ID

            UPDATE dbo.Phone_Active_Kit ----Needed for BYOP Activated handset
            SET
                Pin_Number = p1.Pin_Number
                , Area_Code = p1.Area_Code
                , order_no = p1.order_no
                , Active_Status = p1.Active_Status
            --SELECT 
            --    p.Pin_Number, p1.Pin_Number
            --    , p.Area_Code, p1.Area_Code
            --    , p.order_no, p1.order_no
            --    , p.Active_Status, p1.Active_Status
            FROM
                dbo.Phone_Active_Kit AS P
            JOIN #OldESN AS P1
                ON P1.Sim_ID = P.Sim_ID
            JOIN #ESNList AS E
                ON E.ESN_SIM = P.Sim_ID
            WHERE
                P.Status = 1 AND--NG20230929
                P.order_no = 0

            UPDATE dbo.Phone_Active_Kit ----Needed for BYOP Activated handset
            SET
                Pin_Number = p1.Pin_Number
                , Area_Code = p1.Area_Code
                , order_no = p1.order_no
                , Active_Status = p1.Active_Status
            --SELECT 
            --    p.Pin_Number, p1.Pin_Number
            --    , p.Area_Code, p1.Area_Code
            --    , p.order_no, p1.order_no
            --    , p.Active_Status, p1.Active_Status
            FROM
                dbo.Phone_Active_Kit AS P
            JOIN #OldSIM AS P1
                ON P1.Sim_ID = P.Sim_ID
            JOIN #ESNList AS E
                ON E.SIM = P.Sim_ID
            WHERE
                P.Status = 1 AND --NG20230929
                P.order_no = 0
            --------------------------------------------------------------------------------------------------------------------------------------
            -- Create records in tblOrderItemAddons
            INSERT INTO dbo.tblOrderItemAddons
            (OrderID, AddonsID, AddonsValue)
            SELECT
                E.ID
                , 17 AS AddonsId -- DeviceType ESN
                , @ESN AS AddonsValue
            FROM #ESNList1 AS E
            JOIN #ESNList AS E2 ON E2.Order_No = E.Order_No
            WHERE
                NOT EXISTS (
                    SELECT oia.AddonsValue
                    FROM dbo.tblOrderItemAddons AS oia
                    JOIN #ESNList1 AS E ON E.ID = oia.OrderID
                    WHERE @ESN = oia.AddonsValue AND E.ID = oia.OrderID
                )

            INSERT INTO dbo.tblOrderItemAddons
            (OrderId, AddonsID, AddonsValue)
            SELECT
                E.ID
                , 21 AS AddonsId -- SimType
                , @SIM AS AddonsValue
            FROM #ESNList1 AS E
            JOIN #ESNList AS E2 ON E2.Order_No = E.Order_No
            WHERE
                NOT EXISTS (
                    SELECT oia.AddonsValue
                    FROM dbo.tblOrderItemAddons AS oia
                    JOIN #ESNList1 AS E ON E.ID = oia.OrderID
                    WHERE @SIM = oia.AddonsValue AND E.ID = oia.OrderID
                )

            INSERT INTO dbo.tblOrderItemAddons
            (OrderId, AddonsID, AddonsValue)
            SELECT
                E.ID
                , 187 AS AddonsId -- KitNoType
                , E2.KitNumber AS AddonsValue
            FROM #ESNList1 AS E
            JOIN #ESNList AS E2 ON E2.Order_No = E.Order_No
            WHERE
                NOT EXISTS (SELECT oia.AddonsValue FROM dbo.tblOrderItemAddons AS oia JOIN #ESNList1 AS E ON E.ID = oia.OrderID WHERE oia.AddonsID = 187); -- noqa: LT05

            --------------------------------------------------------------------------------------------------------------------------------------
            -- Check after update
            --------------------------------------------------------------------------------------------------------------------------------------
            -- Check if values exist in PAK
            SELECT
                o.Order_No
                , o.SKU
                , oia.AddonsValue AS [ICCID]
                , O.Product_ID
                , CASE WHEN oia1.AddonsValue IS NOT NULL THEN 'Yes' ELSE 'No' END AS [IsKitted]
                , pak.Activation_Type
                , oia1.AddonsValue AS [Kit Number]
                , o.Name
                , pm.VendorSku AS [Part Number]
                , ONum.Process
                , ONum.Filled
                , ONum.Void
                , ONum.Paid
                , CASE WHEN a.Account_Name = 'Branded Handset' THEN 'Amplex' ELSE a.Account_Name END AS [Vendor Name]
            FROM dbo.Orders AS o
            JOIN dbo.Order_No AS ONum
                ON ONum.Order_No = O.Order_No
            JOIN dbo.Account AS a
                ON a.Account_ID = o.Dropship_Account_ID
            JOIN Products.tblProductMapping AS pm
                ON o.Product_ID = pm.ProductID
            LEFT JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('SimType', 'SimBYOPType')
                ON oia.OrderID = o.ID
            LEFT JOIN
                dbo.tblOrderItemAddons AS oia1
                    JOIN dbo.tblAddonFamily AS af2
                        ON
                            af2.AddonID = oia1.AddonsID
                            AND af2.AddonTypeName IN ('KitNoType')
                ON oia1.OrderID = o.ID
            LEFT JOIN dbo.Phone_Active_Kit AS pak
                ON
                    pak.PONumber = o.Order_No
                    AND pak.Sim_ID = @ESN
            WHERE o.Order_No = @OrderNo
        END;
    --------------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 2
        BEGIN
            IF @UserID NOT IN (279685, 259617, 145761, 257210, 257210, 262758, 281818) --NG20231129
                RAISERROR (
                    'This user is not authorized to fill this order, please contact T-CETRA Supply Chain team if you need to override this order.',
                    15,
                    1
                );

            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Order_No = @OrderNo AND Process = 1 AND Filled = 1 AND Paid = 1)
                RAISERROR (
                    'The provided Order has already been marked as Paid and cannot be filled. Please check that the correct OrderNo is provided above and try again, otherwise please contact IT Support for assistance.', -- noqa: LT05
                    15,
                    1
                );

            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Order_No = @OrderNo AND Process = 1 AND Filled = 1)
                RAISERROR (
                    'The provided Order has already been marked as filled and cannot be filled again. Please check that the correct OrderNo is provided above and try again.', -- noqa: LT05
                    15,
                    1
                );

            IF EXISTS (SELECT SKU FROM dbo.Orders WHERE SKU IS NULL AND Order_No = @OrderNo)
                RAISERROR (
                    'Device details are still missing from this order. The order cannot be marked as filled while missing device details. Please supply all device details and try again.', -- noqa: LT05
                    15,
                    1
                );

            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Order_No = @OrderNo AND OrderTotal != 0.00)
                BEGIN
                    UPDATE dbo.Order_No
                    SET
                        Process = 1
                        , Filled = 1
                        , Void = 0
                        , DateFilled = GETDATE()
                        , Admin_Updated = GETDATE()
                        , Admin_Name = 'FulfillCRMReport'
                    WHERE Order_No IN (SELECT Order_No FROM #ESNList)

                    SELECT Process, Filled, Paid, Void, OrderTotal, DateOrdered, DateFilled, DateDue
                    FROM dbo.Order_No
                    WHERE Order_No = @OrderNo
                END;
            IF EXISTS (SELECT * FROM dbo.Order_No WHERE Order_No = @OrderNo AND OrderTotal = 0.00)
                BEGIN

                    SELECT Orders.Order_No, SUM(Orders.Price - Orders.DiscAmount + Orders.Fee) AS OrderTotal
                    INTO #t1
                    FROM dbo.Orders WHERE Orders.Order_No = @OrderNo GROUP BY Orders.Order_No
                    UPDATE onu
                    SET
                        OrderTotal = t.OrderTotal
                        , onu.Process = 1
                        , onu.Filled = 1
                        , onu.DateFilled = GETDATE()
                        , onu.Admin_Updated = GETDATE()
                        , onu.Admin_Name = 'FulfillCRMReport'
                    FROM dbo.Order_No AS onu JOIN #t1 AS t ON t.Order_No = onu.Order_No
                    WHERE onu.Order_No = @OrderNo

                    SELECT Process, Filled, Paid, Void, OrderTotal, DateOrdered, DateFilled, DateDue
                    FROM dbo.Order_No
                    WHERE Order_No = @OrderNo
                END;
        END;

END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
