--liquibase formatted sql

--changeset Nicolas Griesdorn dc3965fd stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-05-14
				:
	Description	: SP used in CRM to report on errors of Top-Ups by Brand
				:
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_TopUp_Errors_By_Brand]
    (
        @SessionID INT
        , @Carrier INT  --Simple 4 TBV 292 TBV FWA 404 VZW 7
        , @StartDate DATE
        , @EndDate DATE
    )
AS
BEGIN TRY
    IF @EndDate > DATEADD(DAY, +7, @StartDate)
        RAISERROR (
            'The End Date entered is greater then 7 days from the Start Date, please enter a date that is 7 days from the start date or less.', 12, 1
        )
    IF @Carrier <> 404
        BEGIN

            -- All Brands except TBV FWA

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate) --NG20240124
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate) --NG20240124

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [Error Message]
                , af1.AddonTypeName
                , CASE
                    WHEN LEN(oia.AddonsValue) > 4 THEN oia.AddonsValue
                    WHEN LEN(oia.AddonsValue) <= 4 THEN '******' + oia.AddonsValue
                END AS [AddonsValue]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #AllOtherBrand
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    LEFT JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('PhoneNumberType', 'BillItemNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = @Carrier
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (1, 9)
                AND o.Name NOT LIKE '%Total by Verizon Home Internet RTR%'
                AND onu.Void = 1
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate



            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[Error Message]
                , pv.[PhoneNumberType] AS [Phone Number]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [Error Message]
                        , AddonsValue AS [Phone Number]
                        , AddonTypeName
                        , [Activation Platform]
                    FROM #AllOtherBrand
                ) AS APivotTable
            PIVOT
            (
                MAX([Phone Number])
                FOR AddonTypeName IN ([PhoneNumberType], [BillItemNumberType])
            ) pv;


            DROP TABLE IF EXISTS #AllOtherBrand
        END;



    -- TBV FWA NG20240119

    IF @Carrier = 404
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate) --NG20240124
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate) --NG20240124

            DROP TABLE IF EXISTS #TBVFWA

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [Error Message]
                , af1.AddonTypeName
                , CASE
                    WHEN LEN(oia.AddonsValue) > 4 THEN oia.AddonsValue
                    WHEN LEN(oia.AddonsValue) <= 4 THEN '******' + oia.AddonsValue
                END AS [AddonsValue]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #TBVFWA
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    LEFT JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('PhoneNumberType', 'BillItemNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = 292
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (1, 9)
                AND o.Name LIKE '%Total by Verizon Home Internet RTR%'
                AND onu.Void = 1
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate

            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[Error Message]
                , pv.[PhoneNumberType] AS [Phone Number]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [Error Message]
                        , AddonsValue AS [Phone Number]
                        , AddonTypeName
                        , [Activation Platform]
                    FROM #TBVFWA
                ) AS APivotTable
            PIVOT
            (
                MAX([Phone Number])
                FOR AddonTypeName IN ([PhoneNumberType], [BillItemNumberType])
            ) pv;


            DROP TABLE IF EXISTS #TBVFWA
        END;


END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
