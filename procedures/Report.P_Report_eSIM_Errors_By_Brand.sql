--liquibase formatted sql

--changeset Nicolas Griesdorn 5ef059b8 stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2023-05-30
				:
	Description	: SP used in CRM to report on eSIM Activations
				:
	NG20230726	: Added PAK Activation Type (byop/branded/handset) to report
	NG20230801  : Added Simple Mobile brand to report
	NG20240119  : Refactored report to add TBV FWA metrics, users can search based on all carriers except for TBV FWA (Regular TBV is fine) in first select and then by TBV FWA Only in second select. -- noqa: LT05
	NG20240124  : Added more options to ONu.UserIPAddress and changed the Start and EndDates over to IIF options

============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_eSIM_Errors_By_Brand]
    (
        @SessionID INT
        , @Carrier INT --Simple 4 TBV 292 TBV FWA 404 VZW 7
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
                , oia.AddonsValue
                , CASE
                    WHEN pak.Activation_Type = 'byop' THEN 'BYOP'
                    WHEN pak.Activation_Type = 'branded' THEN 'Branded'
                    WHEN pak.Activation_Type = 'handset' THEN 'Handset'
                    ELSE pak.Activation_Type
                END AS [IMEI Type]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #AllOtherBrand
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('DeviceType', 'DeviceBYOPType', 'SimType', 'SimBYOPType', 'ESimType', 'ESimNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = @Carrier
            JOIN dbo.Phone_Active_Kit AS pak ON pak.order_no = o.Order_No AND LEN(pak.Sim_ID) <= 16
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (22, 23)
                AND ISNULL(p.SubProductTypeId, 0) <> 17
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
                , pv.[DeviceBYOPType] AS [ESN]
                , CASE WHEN ISNULL(pv.[SimBYOPType], '') = '' THEN pv.[ESimNumberType] ELSE pv.SimBYOPType END AS [SIM]
                , pv.[IMEI Type]
                , CASE WHEN pv.[ESimType] = 'on' THEN 'eSIM' ELSE 'Not eSIM' END AS [eSIM Type]
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
                        , AddonsValue AS [ESN]
                        , AddonTypeName
                        , [IMEI Type]
                        , [Activation Platform]
                    FROM #AllOtherBrand
                ) AS APivotTable
            PIVOT
            (
                MAX([ESN])
                FOR AddonTypeName IN ([DeviceType], [DeviceBYOPType], [SimType], [SimBYOPType], [ESimType], [ESimNumberType])
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
                , oia.AddonsValue
                , CASE
                    WHEN pak.Activation_Type = 'byop' THEN 'BYOP'
                    WHEN pak.Activation_Type = 'branded' THEN 'Branded'
                    WHEN pak.Activation_Type = 'handset' THEN 'Handset'
                    ELSE pak.Activation_Type
                END AS [IMEI Type]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #TBVFWA
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('DeviceType', 'DeviceBYOPType', 'SimType', 'SimBYOPType', 'ESimType', 'ESimNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = 292
            JOIN dbo.Phone_Active_Kit AS pak ON pak.order_no = o.Order_No AND LEN(pak.Sim_ID) <= 16
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (22, 23)
                AND p.SubProductTypeId = 17
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
                , pv.[DeviceBYOPType] AS [ESN]
                , CASE WHEN ISNULL(pv.[SimBYOPType], '') = '' THEN pv.[ESimNumberType] ELSE pv.SimBYOPType END AS [SIM]
                , pv.[IMEI Type]
                , CASE WHEN pv.[ESimType] = 'on' THEN 'eSIM' ELSE 'Not eSIM' END AS [eSIM Type]
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
                        , AddonsValue AS [ESN]
                        , AddonTypeName
                        , [IMEI Type]
                        , [Activation Platform]
                    FROM #TBVFWA
                ) AS APivotTable
            PIVOT
            (
                MAX([ESN])
                FOR AddonTypeName IN ([DeviceType], [DeviceBYOPType], [SimType], [SimBYOPType], [ESimType], [ESimNumberType])
            ) pv;


            DROP TABLE IF EXISTS #TBVFWA
        END;


END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
