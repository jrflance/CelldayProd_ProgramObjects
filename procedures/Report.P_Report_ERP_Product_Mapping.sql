--liquibase formatted sql

--changeset Nicolas Griesdorn 1266d413 stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-03-10git
				:
	Description	: SP used in CRM to mapping ERP Products to one another
				:
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_ERP_Product_Mapping]
    (
        @SessionID INT
        , @VP_ProductID VARCHAR(MAX)
        , @NS_ProductID INT
        , @Option INT --View,Update,Insert
    )
AS
BEGIN TRY
    ----Error Handling (Global)---------------------------------------------------------------------------------------------------------------
    IF ISNULL(@SessionID, 0) <> 2
        RAISERROR ('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

        --------------------------------------------------------------------------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#ListOfVPPIDS') IS NOT NULL
        BEGIN
            DROP TABLE #ListOfVPPIDS;
        END;

    CREATE TABLE #ListOfVPPIDS (VP_ProductID INT)
    INSERT INTO #ListOfVPPIDS (VP_ProductID)
    SELECT RESULT
    FROM [dbo].[FnGetStringInTable](@VP_ProductID, ',')
    ------View----------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 0
        BEGIN
            SELECT ise.*
            FROM #ListOfVPPIDS AS lovp
            JOIN pl01.QEDL.ItemSentERP AS ise ON ise.VP_Product_ID = lovp.VP_ProductID
        END;
        ------Update--------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 1
        BEGIN
            IF NOT EXISTS (SELECT ise.VP_Product_ID FROM pl01.QEDL.ItemSentERP AS ise JOIN #ListOfVPPIDS AS lov ON ise.VP_Product_ID = lov.VP_ProductID) -- noqa: LT05
                RAISERROR (
                    'One or more of the VP Product IDs entered does not exist in this table, please use the insert option to complete this update.', -- noqa: LT05
                    13,
                    1
                );


            MERGE pl01.QEDL.ItemSentERP AS ise
            USING #ListOfVPPIDS AS lovp
                ON lovp.VP_ProductID = ise.VP_Product_ID
            WHEN MATCHED
                THEN UPDATE SET ise.ERP_Product_ID = @NS_ProductID, ise.dt_MappingUpdated = GETDATE(), ise.User_Updated = 'ERPProductMappingCRM'
            WHEN NOT MATCHED
                THEN INSERT
                    (VP_Product_ID, ERP_Product_ID, dt_ItemSentERP, dt_ItemProcessedERP, dt_ItemCreateERP, dt_MappingUpdated, User_Updated)
                VALUES (lovp.VP_ProductID, @NS_ProductID, GETDATE(), GETDATE(), GETDATE(), NULL, 'ERPProductMappingCRM');

            SELECT ise.*
            FROM pl01.QEDL.ItemSentERP AS ise
            JOIN #ListOfVPPIDS AS lovp ON ise.VP_Product_ID = lovp.VP_ProductID


        END;
        --------Insert--------------------------------------------------------------------------------------------------------------------------------
    IF @Option = 2
        BEGIN

            IF
                EXISTS (
                    SELECT ise.VP_Product_ID FROM pl01.QEDL.ItemSentERP AS ise JOIN #ListOfVPPIDS AS lov ON ise.VP_Product_ID = lov.VP_ProductID
                )
                RAISERROR (
                    'One or more of the VP Product IDs entered already exists in this table, please use the update option to complete this update.', -- noqa: LT05
                    14,
                    1
                );

            MERGE pl01.QEDL.ItemSentERP AS ise
            USING #ListOfVPPIDS AS lovp
                ON lovp.VP_ProductID = ise.VP_Product_ID
            WHEN NOT MATCHED
                THEN INSERT
                    (VP_Product_ID, ERP_Product_ID, dt_ItemSentERP, dt_ItemProcessedERP, dt_ItemCreateERP, dt_MappingUpdated, User_Updated)
                VALUES (lovp.VP_ProductID, @NS_ProductID, GETDATE(), GETDATE(), GETDATE(), NULL, 'ERPProductMappingCRM');

            SELECT ise.*
            FROM pl01.QEDL.ItemSentERP AS ise
            JOIN #ListOfVPPIDS AS lovpp ON ise.VP_Product_ID = lovpp.VP_ProductID
        END;
END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
